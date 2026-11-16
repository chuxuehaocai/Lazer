#!/usr/bin/env bash
# Re-signs the unsigned IPA while keeping its entitlements - and, crucially,
# rewrites the App Group to one your own team can actually create.
#
# App Groups are registered per team. The group this repo builds with,
# `group.dev.naominet.lazer`, belongs to the Lazer team: a different team cannot
# create it, cannot join it, and `containerURL` returns nil in both processes, so
# the widget stays empty. Re-signing therefore has to do two things at once:
#
#   1. rewrite `LAZER_APP_GROUP_IDENTIFIER` to `group.<your-team-or-bundle-prefix>`
#   2. sign both bundles with a profile that carries that group
#
# Step 1 is a plist rewrite, not a rebuild, because the identifier reaches the
# code through each bundle's Info.plist instead of a Swift literal.
#
#   bash ci/resign-ios-ipa.sh \
#       --ipa dist/Lazer-v2.0.210-iOS-aarch64.ipa \
#       --profile ~/Library/MobileDevice/Provisioning\ Profiles/lazer.mobileprovision \
#       --identity "Apple Development: you@example.com (TEAMID)" \
#       --app-group group.com.example.lazer \
#       --out dist/Lazer-resigned.ipa
#
# Requires macOS with Xcode command-line tools.
set -euo pipefail

ipa=""
profile=""
identity=""
app_group=""
output=""

usage() {
    cat >&2 <<'EOF'
Usage: bash ci/resign-ios-ipa.sh --ipa FILE --profile FILE --identity NAME
                                 --app-group GROUP [--out FILE]
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) ipa="$2"; shift 2 ;;
        --profile) profile="$2"; shift 2 ;;
        --identity) identity="$2"; shift 2 ;;
        --app-group) app_group="$2"; shift 2 ;;
        --out) output="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done
[[ -n "$ipa" && -n "$profile" && -n "$identity" && -n "$app_group" ]] || usage
[[ "$(uname -s)" == "Darwin" ]] || { echo "re-signing needs macOS and Xcode." >&2; exit 2; }
[[ -f "$ipa" ]] || { echo "missing IPA: $ipa" >&2; exit 1; }
[[ -f "$profile" ]] || { echo "missing profile: $profile" >&2; exit 1; }
case "$app_group" in
    group.*) ;;
    *) echo "--app-group must start with 'group.', got: $app_group" >&2; exit 2 ;;
esac
output="${output:-${ipa%.ipa}-resigned.ipa}"

stage="$(mktemp -d -t lazer-resign)"
trap 'rm -rf "$stage"' EXIT
unzip -q "$ipa" -d "$stage"

app="$stage/Payload/Runner.app"
[[ -d "$app" ]] || { echo "$ipa has no Payload/Runner.app" >&2; exit 1; }

# The profile decides which App Group is legal. Reading it up front turns the
# most common mistake - signing with a group the profile does not carry - into a
# clear message instead of a silent empty widget on the device.
profile_plist="$stage/profile.plist"
security cms -D -i "$profile" -o "$profile_plist"
profile_groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' \
    "$profile_plist" 2>/dev/null || true)"
if [[ -z "$profile_groups" ]]; then
    cat >&2 <<EOF
error: this profile carries no App Groups entitlement.

A free Apple ID profile cannot carry one, so the widget can only ever show its
"not enabled" state. To get a populated widget you need either:
  * a paid developer account, with an App Group created in the portal and
    enabled on the App ID of both bundles, or
  * a sideload tool that preserves entitlements it cannot validate (TrollStore
    on a supported iOS version installs the original signature as-is).
EOF
    exit 1
fi
if ! grep -qF "$app_group" <<<"$profile_groups"; then
    echo "error: $app_group is not in the profile. It carries:" >&2
    sed 's/^/  /' <<<"$profile_groups" >&2
    exit 1
fi

team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")"
app_id_prefix="${profile_app_id%%.*}"

# The profile's App ID has to accept every bundle identifier in the package. A
# wildcard (`TEAMID.*`) accepts all of them; anything else names one app, and
# installing it over a different identifier fails on the device with no useful
# message. Checking here is the difference between "why won't it install" and a
# line saying which flag to pass.
app_id_matches() {
    local bundle_id="$1"
    case "$profile_app_id" in
        *\*) [[ "$bundle_id" == ${profile_app_id#*.} ]] || [[ "${profile_app_id#*.}" == \* ]] ;;
        *) [[ "$bundle_id" == "${profile_app_id#*.}" ]] ;;
    esac
}

bundles=()
while IFS= read -r -d '' candidate; do
    bundles+=("$candidate")
done < <(find "$app" -name '*.appex' -type d -print0)

# Every identifier in the package has to be installable under this profile.
for bundle in "$app" "${bundles[@]}"; do
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Info.plist")"
    if ! app_id_matches "$bundle_id"; then
        cat >&2 <<EOF
error: the profile installs '${profile_app_id#*.}', not '$bundle_id'.

Use a wildcard profile (TEAMID.*), or one whose App ID is '${profile_app_id#*.}'.
The widget extension needs its own identifier under the same App ID, so a
wildcard is the only profile that covers the whole package.
EOF
        exit 1
    fi
done

# Rewrite the identifier every bundle was built with. `LazerAppGroupIdentifier`
# is what the Swift code reads, so this is the only place the value has to agree.
rewrite_group() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c "Set :LazerAppGroupIdentifier $app_group" "$plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :LazerAppGroupIdentifier string $app_group" "$plist"
}

rewrite_group "$app/Info.plist"
for bundle in "${bundles[@]}"; do
    rewrite_group "$bundle/Info.plist"
done

# Entitlements: start from the ones the bundle already carries and change only the
# group. This is the point of re-signing "as-is": the original declaration holds
# options a from-scratch template would lose (associated domains, keychain
# groups, background modes), and dropping one of those breaks a feature that has
# nothing to do with the widget.
extract_entitlements() {
    local bundle="$1" out="$2"
    rm -f "$out"
    if /usr/bin/codesign -d --entitlements :- "$bundle" > "$out" 2>/dev/null \
        && [[ -s "$out" ]] \
        && /usr/libexec/PlistBuddy -c 'Print' "$out" >/dev/null 2>&1; then
        return 0
    fi
    : > "$out"
    return 1
}

write_minimal_entitlements() {
    local out="$1"
    cat > "$out" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
}

# Keeps everything, replaces the group list with the one the profile carries.
fix_entitlements() {
    local bundle="$1" bundle_id="$2" out="$3"
    if ! extract_entitlements "$bundle" "$out"; then
        echo "  ${bundle##*/}: no readable entitlements, using a minimal set" >&2
        write_minimal_entitlements "$out"
    fi
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$out" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$out"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $app_group" "$out"
    # The application-identifier and team have to follow the signing team, or the
    # profile and the signature disagree and the install fails outright.
    /usr/libexec/PlistBuddy -c "Set :application-identifier $app_id_prefix.$bundle_id" "$out" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :application-identifier string $app_id_prefix.$bundle_id" "$out"
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $team_id" "$out" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team_id" "$out"
}

sign_bundle() {
    local bundle="$1" bundle_id="$2"
    local ent="$stage/entitlements-$bundle_id.plist"
    # iOS only honours a signature that carries its profile inside the bundle.
    # TrollStore ignores this, every other installer does not.
    cp "$profile" "$bundle/embedded.mobileprovision"
    fix_entitlements "$bundle" "$bundle_id" "$ent"
    /usr/bin/codesign --force --sign "$identity" \
        --entitlements "$ent" \
        --timestamp=none \
        --generate-entitlement-der \
        "$bundle"
}

# Extensions first: the enclosing app's signature seals them.
for bundle in "${bundles[@]}"; do
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Info.plist")"
    sign_bundle "$bundle" "$bundle_id"
done
sign_bundle "$app" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

# Verify what was produced instead of trusting codesign's exit status: an
# entitlement the profile does not allow is dropped silently otherwise, which is
# exactly how a widget ends up empty after a "successful" re-sign.
for bundle in "$app" "${bundles[@]}"; do
    /usr/bin/codesign --verify --deep --strict "$bundle"
    actual="$(
        /usr/bin/codesign -d --entitlements :- "$bundle" 2>/dev/null \
            | /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' /dev/stdin 2>/dev/null \
            || true
    )"
    if [[ "$actual" != "$app_group" ]]; then
        echo "error: ${bundle##*/} signed without $app_group (got: ${actual:-none})" >&2
        echo "       the profile most likely does not allow it on this App ID." >&2
        exit 1
    fi
    echo "signed ${bundle##*/}: $actual"
done

mkdir -p "$(dirname "$output")"
rm -f "$output"
( cd "$stage" && zip -qry "$output" Payload )
echo "wrote $output"
