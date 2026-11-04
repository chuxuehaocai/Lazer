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

- **Startup.** `AppShell` schedules a check four seconds after the first
  frame when production enables `autoCheckUpdates`. At most one automatic check
  runs per 24 hours (`AppState.updateCheckInterval`); the timestamp of the last
  successful check is persisted.
- **Settings → About → 检查更新.** A manual check ignores both the daily
  interval and a previous skip.

A check has an 8-second timeout and routes through the same system proxy as the
external charts (`SystemHttpProxy`). Failures are silent on startup and produce
a short snack bar for a manual check.

## Reminding and skipping

A found release opens one dialog with the release name, notes, version pair and
the release page URL:

- **前往下载** opens the page in the system browser. Desktop starts
  `rundll32`/`xdg-open`; Android answers a small
  `dev.naominet.lazer/updates` channel. No `url_launcher` dependency is needed.
- **稍后** closes the dialog for this session. The next launch may offer the
  same release again after the daily interval.
- **跳过此版本** persists the normalised version in
  `lazer_skipped_update`. Automatic checks ignore exactly that version; a newer
  release still prompts. The About section shows the skipped version with a
  **恢复提醒** action, so a skip is never a dead end.

The jump from a skipped release to a newer one is intentional: skipping beta 2
does not silence the beta 3 announcement.

## Tests

`test/update_checker_test.dart` covers version parsing and ordering, release
selection for stable and pre-release builds, drafts/malformed tags, HTTP
failures, the daily cadence, and the skip/manual override. `http.Response`
objects are injected, so the suite never touches the network.
