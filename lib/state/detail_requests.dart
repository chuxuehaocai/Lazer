import 'build_safe_notifier.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Album names appear all over the app — library rows, search results, the
/// player's metadata — but the shell owns the right-hand detail slot. A small
/// request bus keeps every one of those call sites free of shell plumbing: they
/// publish the album, the shell picks it up and loads the playlist pipeline
/// with it.
final ValueNotifier<Album?> albumDetailRequest = BuildSafeValueNotifier<Album?>(
  null,
);

/// Artist links use the same right-hand detail slot as playlists and albums.
final ValueNotifier<ArtistRef?> artistDetailRequest =
    BuildSafeValueNotifier<ArtistRef?>(null);
