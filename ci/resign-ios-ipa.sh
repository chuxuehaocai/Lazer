#!/usr/bin/env bash
# Re-sign with Apple's codesign. Provide a profile per target when using
# explicit App IDs (required by App Groups); a covering wildcard still works.
#
# bash ci/resign-ios-ipa.sh --ipa dist/Lazer-iOS-aarch64.ipa \
#   --profile app.mobileprovision --identity 'Apple Development: ...' \
#   --extension-profile dev.naominet.lazer.PlayCountWidget=widget.mobileprovision \
#   --app-group group.com.example.lazer --out dist/Lazer-signed.ipa
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 're-signing needs macOS and Xcode.' >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$repo/ci/resign-ios-ipa.py" --backend codesign "$@"
