# Music gateways

## Current scope

The provider-neutral gateway layer and the experimental Navidrome backend are
integrated into the shared desktop, phone and large-screen UI. Open Music platform
from Settings or the account menu to add a server or select an existing connection.
Navidrome uses the existing home, search, library, album, artist and player views.

Server addresses, usernames and selected connection are restored on launch.
Navidrome credentials remain in memory; opening the application again requires
signing in to that server. Switching platforms retains each live connection's
session and clears the previous playback queue and detail view. Signing out of
Navidrome leaves the independent NetEase session intact.

## Layout

| File | Responsibility |
| --- | --- |
| `music_gateway.dart` | Protocol-neutral catalogue, account and playback boundary |
| `music_models.dart` | Opaque, namespaced IDs and typed music values |
| `gateway_registry.dart` | Independent connections, active selection and ID routing |
| `netease_music_gateway.dart` | New interface backed by the existing NetEase implementation |
| `navidrome_gateway.dart` | Experimental Subsonic/OpenSubsonic adapter |
| `navidrome_transport.dart` | Authentication, HTTP, media URLs and safe transport failures |
| `netease_gateway.dart`, `legacy_models.dart` | Existing NetEase API and compatibility models |
| `gateway.dart` | Compatibility exports; existing imports continue to work |
| `../data/platform_catalog.dart` | Maps provider values into shared UI models |
| `../state/music_platform_state.dart` | Connect/select, account state and native playback actions |
| `../legacy/navidrome_login_fields.dart` | Shared server login form |
| `../animation/view_transitions.dart` | Nonlinear form, tab and desktop route transitions |

New consumers should use `MusicGateway` and `MusicId`. The legacy NetEase API is
retained to keep the running application compatible while consumers migrate.

## Connect and select

```dart
import 'package:lazer_nextgen/gateway/gateway.dart';

final connections = GatewayRegistry();
final navidrome = NavidromeGateway(
  serverUrl: 'https://music.example/navidrome',
  username: username,
);
await navidrome.login(password);
connections.add(navidrome, select: true);

final netease = NeteaseMusicGateway(connectionId: 'netease-main');
connections.add(netease);
await netease.loginWithCookie(cookie);

final active = connections.active!;
final results = await active.search('Nocturne', limit: 20);
if (results.songs.items.isNotEmpty) {
  final song = results.songs.items.first;
  final owner = connections.resolve(song.id);
  final source = await owner.stream(song.id);
  // Pass source.uri to the audio engine. Do not log signed media URLs.
}

connections.select(GatewayRegistry.keyOf(netease));
// Saved song IDs still resolve to their original connection.
connections.close();
```

When wrapping an existing NetEase gateway, pass
`NeteaseMusicGateway(connectionId: ..., gateway: existingGateway)`.
Closing that wrapper leaves the borrowed gateway and its session intact. Calling
`clearSession()` explicitly signs out the borrowed gateway.

For QR/SMS login, the existing NetEase-specific methods remain on `legacy`.
After they finish, call `checkSession()` on the new adapter to adopt the profile.
The provider-neutral API has no cookie, phone-number or QR-code assumptions.

## IDs, accounts and caching

`MusicId` includes provider, connection, entity kind and the original remote ID.
Navidrome connection identity includes the canonical server root and username.
Different servers and accounts can use identical remote IDs without colliding.
Reverse proxy path prefixes are preserved; a trailing `/rest/` is accepted.

Serialize references with `MusicId.toJson()` and restore them with
`MusicId.fromJson()`. Shared models store the encoded reference in string IDs;
artist links use `ArtistRef.platformKey` and track album links use `Track.albumKey`.
The queue serializer preserves these references and removes signed artwork URLs.
Do not hash remote IDs into fake NetEase integer IDs or call
`int.parse()` on provider-neutral IDs.

Use `gateway.cacheNamespace` and `MusicId.cacheKey` for account/catalogue and
media cache identity. These are key helpers, not a replacement cache store.
Never use a bare song ID, username alone or signed stream URL as the cache key.
Route playback, downloads, metadata and favorites through
`connections.resolve(song.id)`, not through the currently selected platform.

Navidrome requests that complete after sign-out or session replacement are
rejected. A rejected login preserves the previous valid session.
Home snapshots with signed artwork are fetched per connection rather than saved
as persistent catalogue JSON. Audio-cache keys include the complete song reference.

## Experimental Navidrome

`MusicProvider.navidrome.experimental` is `true`. Show a visible, localized
"Experimental" badge beside Navidrome in the platform list, login form and active
account details. NetEase's flag is `false`.

Supported backend operations:

- Username/password login, session verification and explicit session restoration.
- Search for songs, albums, artists and accessible playlists.
- Album browsing, album tracks, artist albums and complete playlist contents.
- Playlist creation with explicit visibility, repeated song additions and removal
  by playlist index, including duplicate song occurrences.
- Starred songs, star/unstar, original streams and MP3 transcoding requests.
- Structured timed lyrics, older lyric endpoint fallback and play scrobbling.
- Random songs as the provider's recommendation source.

Inspect `supports(MusicCapability...)` before showing provider-specific features.
Navidrome does not advertise NetEase comments or listen-together capabilities.
Its random-song feed is not a personalized NetEase recommendation feed.

Album browsing is available when `browseAlbums` is advertised. NetEase does not
currently advertise that operation through the new interface. Paging uses
`MusicPage.nextOffset`; a full 500-album page can require one final empty read.

Navidrome album/artist/playlist detail endpoints return complete collections;
the adapter slices those responses locally. Playlist search filters the
accessible playlist list because Subsonic search does not include playlists.
Playlist contents retain ordering and duplicates.

NetEase can only remove playlist entries by song ID. The new adapter rejects
positional deletion involving duplicate song IDs before changing the playlist.

## Session and URL handling

The password is used to derive the Subsonic token and is not retained by the
adapter. `session.toJson()` still contains a reusable credential: if persistence
is needed, save it in OS secure storage, not SharedPreferences, logs, catalogue
snapshots or queue JSON. Restore it with `NavidromeSession.fromJson()` followed
by `restoreSession()`, which verifies it before adoption.

HTTPS is the default. For an intentionally configured local HTTP server, create
the gateway with `allowInsecureHttp: true`; use the same option when decoding a
saved HTTP session. Playback and artwork URLs preserve the configured scheme and
proxy prefix. Do not pass them through NetEase helpers that rewrite HTTP to HTTPS
or add NetEase CDN resize parameters.

API credentials are sent in form POST bodies. Redirects are rejected. Media
URLs carry the token required by Subsonic and must be treated as credentials.
Transport errors retain only a safe endpoint/status/code, not the response body,
password, token or original client exception text. Responses are bounded and
requests have timeouts.

## Shared UI integration

The Settings row, account-menu entry and shared login dialog expose platform
selection. The Navidrome form and active account display a localized Experimental
badge. Saved connections can be selected from the same dialog. Passwords are not
saved with connection preferences.

`Catalog` keeps the legacy NetEase behavior while delegating provider references
to the registered owner. Use `albumDetailsFor`, `albumTracksFor`,
`artistAlbumPageFor` and `artistSongsFor` in shared views; the integer overloads
remain compatible with NetEase callers. Native song references also route audio,
downloads, favorites and lyric requests, including timing offsets, to their owner.
Qualified listens use the provider's scrobble endpoint.

Navidrome original quality requests the server file without transcoding. The
shared quality controls use platform-appropriate descriptions. NetEase charts,
comments and listen-together controls are omitted on Navidrome. Random discovery
and shuffled favorites use the server's own collection.

Forms and search-result categories share eased fade/slide transitions. Desktop
routes use the same curve. Existing shell, player and embedded-settings nonlinear
transitions are retained, with reduced-motion behavior covered by UI tests.

## Verification

Gateway tests cover protocol forms, opaque IDs, routing, session replacement,
metadata, pagination, playlist mutations, favorites, stream quality, lyrics,
scrobbles, error redaction and transport behavior. A loopback HTTP server checks
actual form encoding and playable signed media requests without external accounts.

Existing catalogue, cache, audio-quality, lyric, QR/SMS login, comments and
play-upload tests provide compatibility coverage for the NetEase file extraction.
Shared UI tests cover server login, album/artist navigation, platform switching,
late account responses, signed-out restoration, queue metadata, playback, timed
lyrics, favorites and qualified scrobbles. No real Navidrome server credentials
were supplied; deployment-specific server behavior still requires verification.
