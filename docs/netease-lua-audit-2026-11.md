# NetEase Lua provider audit — 2026-11-07

## Findings and fixes

| Finding | Effect | Fix and regression |
| --- | --- | --- |
| EAPI request plaintext contained an extra literal `json` separator | Lyrics, liked-song IDs, playlist details and other EAPI calls failed against the real service | Match the independently implemented Dart EAPI envelope; tests decrypt every fixture request, parse the JSON segment, and compare the full ciphertext and digest |
| Service error responses were parsed as successful empty collections | An expired session or rejected request looked like an empty library | Check service codes for encrypted and public fallback requests; preserve safe numeric codes, never response bodies |
| Comments used the built-in NetEase gateway, even for Lua tracks | Comments appeared without a supporting plugin; encoded track IDs could not load | Add provider comments operations, route requests and account identity to the song owner; gate desktop and mobile entries on the enabled Lua capability |
| The saved-album capability had no Dart Lua bridge operation | Collection view could not use the advertised feature | Implement `savedAlbums`; use a separate public new-album endpoint for `albums` |
| Song-detail responses could reorder favorite and playlist IDs | Pages could show the wrong order | Reorder detail results to requested IDs; cover offset/lookahead and reordered responses |
| Lyric v1 counters and empty-response handling were incomplete | Missing lyrics could become a false instrumental result | Request v1 version counters at zero, fall back to legacy lyrics, recognize explicit instrumental flags, and leave missing content retryable |
| Playlist removal used an array instead of serialized track IDs; name validation applied Lua length to a string | Mutation requests could be rejected or fail in the embedded VM | Serialize deletion IDs and use `string.len` for the name guard |
| Pattern-based trimming did not work in the embedded VM; email login truncated passwords to 16 characters | Blank names/searches were sent upstream; longer passwords could not authenticate | Trim using byte boundaries, normalize formatted phone accounts, and hash the full password; inspect the actual pre-encryption payload in the VM regression |

## Protocol references

Checked the maintained API implementation's [EAPI encryption](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/util/crypto.js), [lyric v1](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/lyric_new.js), [liked-song IDs](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/likelist.js), [comments](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/comment_music.js) and [comment reactions](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/comment_like.js). The host continues to supply only general-purpose crypto, HTTPS, JSON and isolated storage.

## Reproduction and verification

```powershell
flutter test --no-pub test/netease_lua_plugin_test.dart test/netease_lua_features_test.dart test/netease_lua_playlist_edit_test.dart test/plugin_comments_visibility_test.dart test/song_comments_test.dart
dart run tool/smoke_netease_lua.dart
dart run tool/package_netease_lua.dart
```

The live smoke runs outside Flutter's test HTTP overrides. Public search, timed lyrics and comments returned successfully. Read-only account requests for favorites, playlists and saved albums also returned successfully using a disposable copy of the existing plugin session. The copy is deleted in `finally`; no cookie, account name or signed stream URL is printed or committed. An optional single argument to the smoke tool points to a session `storage.json` to reproduce account reads.

Provider reactions and playlist edits are tested with deterministic transports; the live smoke does not mutate the account. Device playback and network results are distinct from the fake-transport regressions. The import test additionally verifies that the generated ZIP compiles, starts, and registers its gateway through the production plugin manager.

Version 1.0.3 is built from the manifest version. The CI check job runs the regressions and publishes the importable ZIP as `Lazer-NetEase-Lua`.
