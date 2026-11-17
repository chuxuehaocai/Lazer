import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';

import 'support/music_gateway.dart';

class _RadioGateway extends TestMusicGateway {
  final seeds = <MusicId?>[];
  @override
  Future<List<MusicSong>> radio(
    MusicRadioKind kind, {
    MusicId? seed,
    MusicId? playlist,
    int limit = 30,
  }) async {
    seeds.add(seed);
    return [
      MusicSong(
        id: id(MusicEntityKind.song, 'next'),
        title: 'Next',
        artists: const [],
        duration: const Duration(minutes: 3),
      ),
    ];
  }
}

void main() {
  for (final sameOwner in [true, false]) {
    test(
      'heart radio only forwards seeds from its connection: $sameOwner',
      () async {
        final gateway = _RadioGateway();
        final catalog = Catalog(gateway: gateway);
        final liked = Playlist(
          id: gateway.id(MusicEntityKind.playlist, 'liked').cacheKey,
          name: 'Liked',
          trackIds: const [],
          coverSeed: 0,
        );
        final seed = MusicId(
          provider: gateway.provider.id,
          connection: sameOwner ? gateway.connectionId : 'another-account',
          kind: MusicEntityKind.song,
          value: 'alpha-42',
        );
        await catalog.heartModeTracks(liked, seedTrackId: seed.cacheKey);
        expect(
          gateway.seeds.single?.cacheKey,
          sameOwner ? seed.cacheKey : null,
        );
      },
    );
  }
  test(
    'heart radio forwards the numeric compatibility seed to its owner',
    () async {
      final gateway = _RadioGateway();
      final catalog = Catalog(gateway: gateway);
      final liked = Playlist(
        id: gateway.id(MusicEntityKind.playlist, 'liked').cacheKey,
        name: 'Liked',
        trackIds: const [],
        coverSeed: 0,
      );
      await catalog.heartModeTracks(liked, seedSongId: 42);
      expect(gateway.seeds.single?.value, '42');
      expect(gateway.seeds.single?.connection, gateway.connectionId);
    },
  );
}
