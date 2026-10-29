import '../data/models.dart';

List<Playlist> uniquePlaylists(List<Playlist> input) {
  final Set<String> seen = <String>{};
  return <Playlist>[
    for (final Playlist playlist in input)
      if (seen.add(playlist.id)) playlist,
  ];
}
