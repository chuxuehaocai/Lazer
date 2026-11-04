import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/cache/media_cache.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/transport.dart'
    show GatewayServiceException;

const Track _track = Track(
  id: '42',
  title: '曲目',
  artist: '音乐人',
  album: '专辑',
  duration: Duration(minutes: 3),
  coverSeed: 0,
);

class _QualityGateway extends NeteaseGateway {
  _QualityGateway({
    this.available = const <AudioQuality>{},
    this.failAll = false,
  });

  /// Tiers the fake account may receive. A request outside the set returns no
  /// URL, which is how the service answers a missing rendition.
  final Set<AudioQuality> available;
  final bool failAll;
  final List<String> levels = <String>[];

  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    levels.add(level);
    if (failAll) throw const SocketException('offline');
    final AudioQuality? requested = AudioQualityInfo.fromLevel(level);
    if (requested == null || !available.contains(requested)) {
      return GatewaySongUrl(id: id, code: 404);
    }
    return GatewaySongUrl(
      id: id,
      url: 'https://audio.test/$id-${requested.name}.mp3',
      br: requested.bitrate,
      type: 'mp3',
      code: 200,
      level: requested.level,
      size: 4096,
    );
  }
}

class _BitrateGateway extends NeteaseGateway {
  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async =>
      GatewaySongUrl(
        id: id,
        url: 'https://audio.test/$id-low.mp3',
        br: 128000,
        type: 'mp3',
        code: 200,
      );
}

/// Answers the first [refusalsBeforeSuccess] requests per tier with the
/// service's "too frequent" refusal: HTTP 200, an empty entry, and code 406.
class _RateLimitedGateway extends NeteaseGateway {
  _RateLimitedGateway({
    required this.refusalsBeforeSuccess,
    this.available = const <AudioQuality>{},
  });

  final int refusalsBeforeSuccess;
  final Set<AudioQuality> available;
  final List<String> levels = <String>[];
  final Map<String, int> _refused = <String, int>{};

  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    levels.add(level);
    final int refused = _refused[level] ?? 0;
    final AudioQuality? requested = AudioQualityInfo.fromLevel(level);
    if (refused < refusalsBeforeSuccess) {
      _refused[level] = refused + 1;
      return GatewaySongUrl(id: id, code: 406);
    }
    if (requested == null || !available.contains(requested)) {
      return GatewaySongUrl(id: id, code: 404);
    }
    return GatewaySongUrl(
      id: id,
      url: 'https://audio.test/$id-${requested.name}.mp3',
      br: requested.bitrate,
      type: 'mp3',
      code: 200,
      level: requested.level,
      size: 4096,
    );
  }
}

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
      expect(AudioQualityInfo.fromLevel('jymaster'), AudioQuality.lossless);
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
    test('serves the requested tier when the account has it', () async {
      final _QualityGateway gateway = _QualityGateway(
        available: <AudioQuality>{AudioQuality.lossless},
      );
      final Catalog catalog = Catalog(gateway: gateway);
      final AudioSource? source = await catalog.audioSourceFor(
        _track,
        quality: AudioQuality.lossless,
        useCache: false,
      );
      expect(source?.quality, AudioQuality.lossless);
      expect(source?.url, 'https://audio.test/42-lossless.mp3');
      expect(source?.format, 'mp3');
      expect(gateway.levels, <String>['lossless']);
    });

    test(
      'falls through every lower tier when a rendition is refused',
      () async {
        final _QualityGateway gateway = _QualityGateway(
          available: <AudioQuality>{AudioQuality.higher},
        );
        final Catalog catalog = Catalog(gateway: gateway);
        final AudioSource? source = await catalog.audioSourceFor(
          _track,
          quality: AudioQuality.lossless,
          useCache: false,
        );
        expect(source?.quality, AudioQuality.higher);
        expect(source?.url, 'https://audio.test/42-higher.mp3');
        expect(gateway.levels, <String>['lossless', 'exhigh', 'higher']);
      },
    );

    test(
      'reports the granted tier when the service returns a lower one',
      () async {
        final Catalog catalog = Catalog(gateway: _BitrateGateway());
        final AudioSource? source = await catalog.audioSourceFor(
          _track,
          quality: AudioQuality.exhigh,
          useCache: false,
        );
        expect(source?.quality, AudioQuality.standard);
      },
    );

    test('a transport failure stops the upstream fallback retries', () async {
      final _QualityGateway gateway = _QualityGateway(failAll: true);
      final Catalog catalog = Catalog(gateway: gateway);
      await expectLater(
        catalog.audioUrlFor(_track, quality: AudioQuality.lossless),
        throwsA(isA<SocketException>()),
      );
      expect(gateway.levels, <String>['lossless']);
      expect(catalog.online, isFalse);
    });

    test(
      'a rate refusal with an empty URL retries its tier, not the song',
      () async {
        // Holding "next" makes the service answer HTTP 200 with an empty entry
        // carrying the refusal code. That must not be reported as an
        // unavailable song: each tier is asked again after a pause, and the
        // answer that finally succeeds is the one that plays.
        final _RateLimitedGateway gateway = _RateLimitedGateway(
          refusalsBeforeSuccess: 1,
          available: <AudioQuality>{AudioQuality.higher},
        );
        final Catalog catalog = Catalog(gateway: gateway);
        final AudioSource? source = await catalog.audioSourceFor(
          _track,
          quality: AudioQuality.lossless,
          useCache: false,
        );
        expect(source?.quality, AudioQuality.higher);
        expect(
          gateway.levels,
          <String>[
            'lossless',
            'lossless',
            'exhigh',
            'exhigh',
            'higher',
            'higher',
          ],
          reason: 'every tier is asked exactly twice: refused, then granted',
        );
      },
    );

    test(
      'a rate refusal that persists is reported as a service refusal',
      () async {
        final Catalog catalog = Catalog(
          gateway: _RateLimitedGateway(
            refusalsBeforeSuccess: 100,
            available: <AudioQuality>{},
          ),
        );
        await expectLater(
          catalog.audioUrlFor(_track, quality: AudioQuality.lossless),
          throwsA(
            isA<GatewayServiceException>().having(
              (GatewayServiceException e) => e.code,
              'code',
              406,
            ),
          ),
        );
      },
    );

    test(
      'a lower-tier cache entry still plays after a transport failure',
      () async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'lazer-quality-fallback-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final DiskCache disk = DiskCache(directory: () async => directory);
        final File? cached = await disk.put(
          CacheBucket.audio,
          AudioCache.cacheKey(_track.id, AudioQuality.standard),
          () => Stream<List<int>>.value(<int>[1, 2, 3]),
          extension: 'mp3',
        );
        final Catalog catalog = Catalog(
          gateway: _QualityGateway(failAll: true),
          cache: disk,
        );
        final AudioSource? source = await catalog.audioSourceFor(
          _track,
          quality: AudioQuality.lossless,
        );
        expect(source?.url, cached!.uri.toString());
        expect(source?.quality, AudioQuality.standard);
      },
    );
  });
}
