# Music gateways

The default connection is local music. Installed and enabled Lua ZIP plugins
supply the available streaming platforms. Platform names, login methods and
capabilities come from the plugin's `describe` response; the application does
not use a fixed NetEase/Navidrome list for platform selection.

## Runtime flow

1. `PluginManager` restores enabled ZIP plugins and starts an isolated VM for
   each plugin. Its `describe` operation may return multiple providers.
2. Each provider becomes a `LuaMusicGateway`. Calls receive `args.platform`;
   IDs include provider, connection and entity type.
3. The client restores each provider's session through `session`, then restores
   the selected connection. Every connection keeps its own signed-in account;
   local playback can retain the last account in the account display.
4. Importing or enabling a plugin registers its providers immediately. Updating,
   disabling or uninstalling a plugin detaches all of its providers. Local
   playback is retained when an unrelated plugin changes.

`MusicGateway` and `MusicId` are the shared model boundary. `platform_catalog.dart`
maps those values into the existing home, search, library, album, artist, lyrics
and player views. No Dart service adapters, endpoint tables or platform lists are bundled.
Application startup selects `LocalMusicGateway` and registers streaming
providers only from installed Lua plugins. Tests use in-memory neutral
gateways and real Lua sandboxes.

## Authentication

Supported login modes are declared as `qr`, `sms`, `password` and `cookie`.
The chooser renders only those declared by its active plugin. Without a
streaming plugin it offers plugin management instead of a service login.

Session credentials are stored inside that plugin's data directory through
`host.storage_*`; they are not put in connection preferences. Connection
preferences store only the selected source and last account identity. Selecting
local music keeps all platform sessions. `AppState.musicAccounts` exposes the
signed-in accounts by connection key; `activeMusicSignedIn` describes the current
source, while the account display may retain the last account in local mode.
`signOut(connectionKey: ...)` logs out only that connection and removes its remote
queue items; accounts and locally available files from other sources remain.

Browsing source selection preserves playback. Queue entries carry their own
`MusicId`, so streaming, metadata, favorites and scrobbling resolve the owning
gateway regardless of the selected source. A late login or metadata response
cannot overwrite another connection's account or content. Login generation
checks prevent an earlier request from reviving a logged-out account.

## Playlist snapshots

Platform collections and complete playlist contents use the shared memory LRU,
request coalescing and disk snapshots. Keys include provider, connection and
account, including when opening a playlist from an inactive source. Cold views
paint stored content before requesting an update; expired data remains an offline
fallback. Explicit refresh and mutations invalidate both layers, and a changed
account during pagination cannot populate the previous account's snapshot.

An owned playlist marked `isFavorites` is the canonical liked collection. Its
remote ID and name (for example, `<username>喜欢的音乐`) remain intact and it is
removed from the regular created/subscribed lists. Providers without a real
favorites playlist get one synthetic collection. Favorites mutations invalidate
both canonical and synthetic playlist snapshots. The library also excludes owned
playlists from its public recommendation shelf.

QR URLs are opaque to the client. The adapter remembers the plugin's key/URL
pair and routes polling back to the same provider. After code 803, it waits
for the account to become available before reporting login success; a spent
key is not polled again during this wait. Changing platforms invalidates late
responses. Creating a QR session preserves any existing authenticated account.

## NetEase plugin and verification

Source: `E:/projects/lazer_ncm/netease-cloud`.
The ZIP is built and used only for local verification; it is intentionally not
checked into this repository or uploaded to the plugin market.
Navidrome has no Lua package yet and is not advertised by this plugin.

The NetEase service protocol, request paths, cookies, AES/RSA envelopes and
response mapping are implemented in Lua. The host supplies general HTTP,
cryptographic, cookie-header and storage primitives. The bundled Dart Lua VM
includes a nested async-call fix so host requests can occur inside helper
functions, loops and protected calls without replaying requests.

`test/lua_plugin_test.dart` covers asynchronous requests and recovery;
`test/lua_platform_integration_test.dart` covers multiple Lua providers, dynamic
login controls, import/toggle/update/uninstall and startup session restoration.

`tool/verify_lua_gateway.dart` is an opt-in live check. It reads a plugin ZIP
and a Cookie file supplied as command arguments, records only PASS/FAIL, tests
QR creation and polling, catalogue endpoints, full favorites pagination, actual
media bytes, restart login and local logout. `tool/verify_lua_gateway_app_test.dart`
also verifies import, library loading, selection and restart through `AppState`.
Both use a temporary data directory and delete it when finished. They do not
bundle credentials or copy the Cookie file into source or the ZIP.

References retain provider, connection and entity type. Route playback, downloads, metadata and favorites through `connections.resolve(id)`. Never coerce opaque IDs to integers or persist signed media URLs.

## Local mode and offline lyrics

The local Home retains Recent, filtered against available imported, downloaded
and cached files. Search matches the local library by title, translation,
artist and album. Likes is omitted from mobile, desktop and television
navigation; Home comes first on desktop.

Audio caching and explicit downloads also save timed lyrics and translations
under application support storage (`cached_lyrics`). A file-path alias recovers
lyrics if cached audio is re-scanned with a new local ID. Imported LRC files are
copied to `imported_lyrics`, so removing the original does not break playback.
Imports take precedence over automatic caches.

## Plugin market and installation

The market defaults to `https://lazer.naominet.dev/plugin` and reads
`plugins.json`, following the website's schema version 1. Sources can be changed
and are persisted. Listings support localized metadata, search, refresh,
platform/minimum-version checks, installation and updates. Downloads show
progress, can be cancelled, and are bounded to 16 MB. Optional SHA-256 checks
and required manifest ID/version checks run before replacing an installation.

ZIP decoding and validation run in a worker isolate. File selection uses the
registered Windows/Linux/macOS/Android/iOS implementations, with ZIP extensions,
MIME types and the `public.zip-archive` UTI. Cancellation and picker errors leave
the install button usable. Plugin manager and market use the same fade-through
contract on incoming and outgoing mobile routes, so transparent pages never
blend their controls during either direction of the transition.
