# Update checks

Lazer looks for newer releases on its own GitHub repository. The check is a
single unauthenticated request to the public releases API; there is no account,
no telemetry, and a failure never interrupts playback or startup.

## Where the current version comes from

`lib/diagnostics/build_info.dart` exposes `BuildInfo.version`. Release builds
are stamped by CI with `--dart-define=LAZER_VERSION=<tag>`; local builds fall
back to the version checked into the source. A branch name is not a version, so
it falls back instead of confusing the comparison. `BuildInfo.displayVersion`
adds the `v` the About row shows.

## What counts as newer

`lib/updates/release_version.dart` implements SemVer precedence:

- tags may be written `v2.0.0-beta.2`, `1.5`, or carry a `+build` suffix;
- `2.0.0-beta.2 < 2.0.0-beta.10 < 2.0.0`;
- numeric pre-release identifiers sort below alphanumeric ones.

Drafts and tags that do not parse are ignored. The newest release strictly
greater than the running version wins. A stable build only considers stable
releases; a pre-release build also considers later pre-releases, so beta users
can move from beta 2 to beta 3 while 2.0 users are not pushed onto a beta.

## When it runs

- **Startup.** `AppShell` schedules a check four seconds after the first frame
  when production enables `autoCheckUpdates`. Every process launch checks once,
  regardless of when the previous launch checked. A persisted timestamp is kept
  for diagnostics, but a device clock correction cannot delay the next launch.
- **Client, then plugins.** The client release is checked first. Installed
  plugins are then compared with the configured plugin market one at a time.
  A user with no installed plugins does not make a market request.
- **Retry.** A failed client check retries after five minutes in the same
  session. If the app is backgrounded or another modal is open, the result or
  prompt is retained and presentation is retried every five seconds without
  repeating the network request.
- **Settings → About → 检查更新.** A manual check ignores both the per-launch
  gate and a previous skip.

A check has an 8-second timeout and routes through the same system proxy as the
external charts (`SystemHttpProxy`). Failures are silent on startup and produce
a short snack bar for a manual check.

## Reminding and skipping

A found release opens one dialog with the release name, notes, version pair and
the release page URL:

When another dialog covers the app or it is in the background, the found
release is retained and presentation is retried every five seconds without
another network request.

- **前往下载** opens the page in the system browser. Desktop starts
  `rundll32`/`open`/`xdg-open`; Android and iOS answer a small
  `dev.naominet.lazer/updates` channel. No `url_launcher` dependency is needed.
- **稍后** closes the dialog for this session. The next launch may offer the
  same release again.
- **跳过此版本** persists the normalised version in
  `lazer_skipped_update`. Automatic checks ignore exactly that version; a newer
  release still prompts. The About section shows the skipped version with a
  **恢复提醒** action, so a skip is never a dead end.

The jump from a skipped release to a newer one is intentional: skipping beta 2
does not silence the beta 3 announcement.

## Plugin updates

Installed plugins share the same startup pass, with their own per-plugin skip
state in `lazer_skipped_plugin_updates`. The client only offers a market version
that is newer than the installed manifest version, compatible with the current
platform and client version, and not already skipped.

- **稍后** ends the remaining plugin queue for this launch.
- **跳过此版本** skips that exact plugin version and continues with the next
  available plugin.
- **更新** downloads the package, verifies its SHA-256 checksum and manifest,
  installs it atomically, and clears the skip entry for that plugin.

Client and plugin checks are independent. A GitHub failure does not prevent a
plugin market check, and a failed plugin download leaves the installed version
untouched.

## Tests

`test/update_checker_test.dart` covers version parsing and ordering, release
selection for stable and pre-release builds, drafts/malformed tags, HTTP
failures, once-per-launch checks, deferred prompts, automatic retry, and the
skip/manual override. `test/startup_updates_test.dart` covers client and plugin
startup sequencing, compatibility filters, per-version plugin skips, and dialog
deferral. `http.Response` objects are injected, so the suite never touches the
network.
