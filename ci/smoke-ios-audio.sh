#!/usr/bin/env bash
# Real iOS Simulator playback using the Release static engine/FFmpeg/bridge.
# No Flutter dependency; errors and the device-driven clock remain in artifacts.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'The iOS Simulator smoke test requires macOS and Xcode.' >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
lib="$repo/build/ios-audio/simulator/stage/lib"
out="$repo/build/ios-audio-smoke"
app="$out/AudioSmoke.app"
bundle=dev.naominet.lazer.audiosmoke
mkdir -p "$app"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios15.0-simulator \
    -isysroot "$sdk" -std=c++20 -fobjc-arc -O2 \
    -I "$repo/native/lazer-audio/include" "$repo/ci/ios-audio-smoke.mm" \
    -Wl,-force_load,"$lib/liblazer-audio.a" \
    -Wl,-force_load,"$lib/liblazer-audio-bridge.a" \
    -L "$lib" -lavformat -lavcodec -lswresample -lavutil \
    -framework UIKit -framework AVFAudio -framework AudioToolbox \
    -framework CoreAudio -framework CoreFoundation -lc++ -Wl,-export_dynamic \
    -o "$app/AudioSmoke"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudioSmoke</string>
<key>CFBundleIdentifier</key><string>dev.naominet.lazer.audiosmoke</string>
<key>CFBundleName</key><string>AudioSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIBackgroundModes</key><array><string>audio</string></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$app"

# Choose an installed iOS runtime and create our own device, leaving any runner
# devices alone. Device type comes from that runtime's existing compatible list.
xcrun simctl list --json > "$out/devices.json"
selection="$(python3 - "$out/devices.json" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
devices = catalog['devices']
types = {entry['name']: entry['identifier'] for entry in catalog['devicetypes']}
for runtime, entries in reversed(list(devices.items())):
    if '.iOS-' not in runtime:
        continue
    for entry in entries:
        device_type = entry.get('deviceTypeIdentifier') or types.get(entry['name'], '')
        if '.iPhone-' in device_type and entry.get('isAvailable', False):
            print(device_type, runtime)
            raise SystemExit(0)
raise SystemExit('No available iPhone Simulator runtime found')
PY
)"
read -r device_type runtime <<< "$selection"
device="$(xcrun simctl create 'Lazer Native Audio Smoke' "$device_type" "$runtime")"
cleanup() {
    xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
xcrun simctl launch --console "$device" "$bundle" > "$out/console.log" 2>&1 &
container="$(xcrun simctl get_app_container "$device" "$bundle" data)"
for ((attempt = 0; attempt < 90; ++attempt)); do
    if [[ -f "$container/Documents/smoke-result.txt" ]]; then
        cp "$container/Documents/smoke-result.txt" "$out/result.txt"
        cat "$out/console.log"
        cat "$out/result.txt"
        grep -q '^PASS ' "$out/result.txt"
        exit $?
    fi
    sleep 1
done
cat "$out/console.log"
echo '::error::iOS native smoke timed out before a playback result.' >&2
exit 1
